import React from 'react';
import {
  DataTable,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableHeader,
  TableRow,
} from '@carbon/react';
import './styles/SimpleTable.scss';

interface SimpleTableProps {
  children: React.ReactNode;
}

const SimpleTable: React.FC<SimpleTableProps> = ({ children }) => {
  const extractTableData = () => {
    const childrenArray = React.Children.toArray(children);

    const thead = childrenArray.find(
      (child: any) => React.isValidElement(child) && child.type === 'thead'
    ) as React.ReactElement<any> | undefined;

    const tbody = childrenArray.find(
      (child: any) => React.isValidElement(child) && child.type === 'tbody'
    ) as React.ReactElement<any> | undefined;

    const headers: Array<{ key: string; header: string }> = [];
    if (thead) {
      const headerRow = React.Children.only(thead.props.children) as React.ReactElement<any>;
      const headerCells = React.Children.toArray(headerRow.props.children);

      headerCells.forEach((cell: any, index) => {
        headers.push({
          key: `col-${index}`,
          header: cell.props.children,
        });
      });
    }

    const rows: Array<{ id: string; [key: string]: any }> = [];
    if (tbody) {
      const bodyRows = React.Children.toArray(tbody.props.children);

      bodyRows.forEach((row: any, rowIndex) => {
        const cells = React.Children.toArray(row.props.children);
        const rowData: { id: string; [key: string]: any } = {
          id: `row-${rowIndex}`,
        };

        cells.forEach((cell: any, cellIndex) => {
          rowData[`col-${cellIndex}`] = cell.props.children;
        });

        rows.push(rowData);
      });
    }

    return { headers, rows };
  };

  const { headers, rows } = extractTableData();

  if (headers.length === 0 || rows.length === 0) {
    return <table>{children}</table>;
  }

  return (
    <DataTable rows={rows} headers={headers}>
      {({ rows, headers, getTableProps, getHeaderProps, getRowProps }: any) => (
        <TableContainer className="simple-table">
          <Table {...getTableProps()}>
            <TableHead>
              <TableRow>
                {headers.map((header: any) => {
                  const { key, ...restHeaderProps } = getHeaderProps({ header });
                  return (
                    <TableHeader key={header.key} {...restHeaderProps}>
                      {header.header}
                    </TableHeader>
                  );
                })}
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((row: any) => {
                const { key, ...restRowProps } = getRowProps({ row });
                return (
                  <TableRow key={row.id} {...restRowProps}>
                    {row.cells.map((cell: any) => (
                      <TableCell key={cell.id}>{cell.value}</TableCell>
                    ))}
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </DataTable>
  );
};

export default SimpleTable;
